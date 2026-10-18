-- ============================================================================
-- 0227 — Cheaper database work: the October performance review's quick fixes
--
-- The production instance is small and has been stalling under background
-- load. Nothing here changes who may read or write what; each part only cuts
-- work the database was doing for nobody, or doing once per row instead of
-- once per statement. Every part is guarded, so it replays on a copy that
-- already has it or lacks a table.
--
-- 1. Realtime publishes only what an app listens to (PERF-26). Every write to
--    a table in supabase_realtime is decoded from the WAL and checked against
--    each subscriber's row-level policies. These tables are written all day
--    and no client subscribes to them -- the app's channels are
--    LiveTables (liveSettingTables + liveOwnTables), AdminLiveTables
--    (liveAdminTables), and the per-feature channels on ride_requests,
--    ride_messages, ride_calls / ride_call_signals, support_calls /
--    support_call_signals, support_messages, active_sessions,
--    user_notifications, wallet_transfer_requests,
--    voice_protection_recordings and app_branding (lib/src/data/*,
--    lib/src/admin/*; the gateway and the edge functions subscribe to none):
--      * user_location_history  -- a row per location fix; the admin page
--                                  reads it on demand
--      * notification_outbox    -- written by every push sent; the Push page
--                                  asks watchAdminLive for it, but it is in
--                                  neither live list, so no channel carries it
--      * wallet_transactions    -- a row per wallet movement; the balance on
--                                  screen follows `wallets`
--      * vehicle_active_session -- the co-driver's current car; read on demand
--      * emergency_contacts     -- read on demand
--      * vehicles               -- not read by the app at all
--      * auth_rate_hits         -- a row per sign-in attempt (only where a
--                                  copy has it in the publication)
--    Kept although they are written often, because something listens:
--    user_sessions (Admin → Session history), messaging_devices and sms_log
--    (liveSettingTables), the call signal tables (during a call),
--    voice_protection_recordings and ev_orders.
-- 2. The admin region list reads two stored columns (PERF-47).
--    geofence_source / geofence_updated_at are generated from the geofence
--    JSON on countries, states, cities and suburbs, so listing the regions
--    no longer detoasts every boundary shape (megabytes for the states) to
--    pull two short strings out of it. The shape itself is still read only
--    when a region is opened.
-- 3. Row-level policies ask "is the caller an admin?" once per statement
--    (PERF-40). A bare caller_is_admin() in USING / WITH CHECK runs (a
--    security-definer lookup) for every row scanned; written
--    `(select public.caller_is_admin())` Postgres runs it once as an
--    InitPlan, as 0163 did for auth.uid(). The same for the other
--    caller-only helpers found bare: caller_admin_can_write('<target>'),
--    caller_is_approved_partner() and is_admin((select auth.uid())). Each
--    policy in public and storage is rewritten from its own stored text, only
--    where it changes; a call already inside a sub-select is left alone.
-- 4. The eleven foreign keys without an index get one (PERF-8), so removing a
--    ride, a profile, a device or a partner doesn't scan the child table.
-- 5. Anonymous requests stop within 8 s (PERF-50). Signed-in requests are
--    already cut at 8 s; a copy where anon has no limit (or a longer one)
--    could hold a connection for as long as a bad anonymous query ran. A
--    copy with a shorter limit (the platform default is 3 s) keeps it.
-- ============================================================================

-- 1. Realtime publication ----------------------------------------------------
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    return;
  end if;
  foreach t in array array[
    'user_location_history',
    'notification_outbox',
    'wallet_transactions',
    'vehicle_active_session',
    'emergency_contacts',
    'vehicles',
    'auth_rate_hits'
  ] loop
    if exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime drop table public.%I', t);
    end if;
  end loop;
end
$$;

-- 2. Region boundary marks as stored columns ----------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['countries', 'states', 'cities', 'suburbs'] loop
    if exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = t
         and column_name = 'geofence' and data_type = 'jsonb'
    ) then
      execute format(
        'alter table public.%I add column if not exists geofence_source text
           generated always as (geofence->>''source'') stored', t);
      execute format(
        'alter table public.%I add column if not exists geofence_updated_at text
           generated always as (geofence->>''updatedAt'') stored', t);
    end if;
  end loop;
end
$$;

-- 3. Caller checks once per statement -----------------------------------------
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
     where p.schemaname in ('public', 'storage')
  loop
    new_using := pol.qual;
    new_check := pol.with_check;
    -- Not part of a longer name, not already the body of a sub-select.
    new_using := regexp_replace(new_using,
      '(?<![[:alnum:]_.])(?<!SELECT )(public\.)?caller_is_admin\(\)',
      '(SELECT public.caller_is_admin())', 'g');
    new_check := regexp_replace(new_check,
      '(?<![[:alnum:]_.])(?<!SELECT )(public\.)?caller_is_admin\(\)',
      '(SELECT public.caller_is_admin())', 'g');
    new_using := regexp_replace(new_using,
      '(?<![[:alnum:]_.])(?<!SELECT )(public\.)?caller_is_approved_partner\(\)',
      '(SELECT public.caller_is_approved_partner())', 'g');
    new_check := regexp_replace(new_check,
      '(?<![[:alnum:]_.])(?<!SELECT )(public\.)?caller_is_approved_partner\(\)',
      '(SELECT public.caller_is_approved_partner())', 'g');
    new_using := regexp_replace(new_using,
      $re$(?<![[:alnum:]_.])(?<!SELECT )(public\.)?caller_admin_can_write\(('[^']*'::text)\)$re$,
      '(SELECT public.caller_admin_can_write(\2))', 'g');
    new_check := regexp_replace(new_check,
      $re$(?<![[:alnum:]_.])(?<!SELECT )(public\.)?caller_admin_can_write\(('[^']*'::text)\)$re$,
      '(SELECT public.caller_admin_can_write(\2))', 'g');
    new_using := regexp_replace(new_using,
      '(?<![[:alnum:]_.])(?<!SELECT )(public\.)?is_admin\(\( SELECT auth\.uid\(\) AS uid\)\)',
      '(SELECT public.is_admin((SELECT auth.uid())))', 'g');
    new_check := regexp_replace(new_check,
      '(?<![[:alnum:]_.])(?<!SELECT )(public\.)?is_admin\(\( SELECT auth\.uid\(\) AS uid\)\)',
      '(SELECT public.is_admin((SELECT auth.uid())))', 'g');

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
    begin
      execute stmt;
    exception when insufficient_privilege then
      -- A copy where this role doesn't own the table (storage, on some
      -- platforms): the policy keeps working as it was.
      raise notice '0227: left % on %.% as it was (not the owner)',
        pol.policyname, pol.schemaname, pol.tablename;
    end;
  end loop;
end
$$;

-- 4. Foreign key indexes --------------------------------------------------------
do $$
declare
  fk record;
begin
  for fk in
    select * from (values
      ('safety_incidents',      'ride_id'),
      ('scheduled_rides',       'ride_id'),
      ('scheduled_ride_offers', 'rider_id'),
      ('scheduled_ride_offers', 'from_id'),
      ('trip_handovers',        'rider_id'),
      ('trip_handovers',        'from_partner_id'),
      ('trip_handovers',        'to_partner_id'),
      ('gateway_pairings',      'created_by'),
      ('gateway_pairings',      'device_row'),
      ('gateway_keys',          'paired_by'),
      ('ev_profiles',           'updated_by')
    ) as t(tbl, col)
  loop
    if exists (
      select 1 from pg_attribute a
       where a.attrelid = to_regclass('public.' || fk.tbl)
         and a.attname = fk.col and a.attnum > 0 and not a.attisdropped
    ) then
      execute format('create index if not exists %I on public.%I (%I)',
                     fk.tbl || '_' || fk.col || '_idx', fk.tbl, fk.col);
    end if;
  end loop;
end
$$;

-- 5. Anonymous statement timeout --------------------------------------------------
do $$
declare
  v_current text;
  v_ms bigint;
  v_orig text := current_setting('statement_timeout');
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    return;
  end if;
  select split_part(cfg, '=', 2) into v_current
    from pg_db_role_setting s
    cross join lateral unnest(s.setconfig) as cfg
   where s.setrole = 'anon'::regrole and s.setdatabase = 0
     and cfg like 'statement_timeout=%';
  if v_current is not null then
    -- Read in milliseconds whatever units it was given in ('3s', '1min').
    perform set_config('statement_timeout', v_current, true);
    v_ms := (select ps.setting::bigint from pg_settings ps where ps.name = 'statement_timeout');
    perform set_config('statement_timeout', v_orig, true);
  end if;
  if v_current is null or v_ms = 0 or v_ms > 8000 then
    begin
      alter role anon set statement_timeout = '8s';
    exception when insufficient_privilege then
      raise notice '0227: anon statement_timeout left as it was (not allowed to change it)';
    end;
  end if;
end
$$;
