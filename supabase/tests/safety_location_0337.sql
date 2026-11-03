-- ============================================================================
-- Regression test for migration 0337: the safety location case and its
-- "no report before disclosure" gate.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/safety_location_0337.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up accounts only.
-- ============================================================================
begin;

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if ok is not true then
    raise exception 'FAILED: %', what;
  end if;
end;
$$;

-- Who is calling: [p_user], role authenticated unless null (the database).
create function pg_temp.as_caller(p_user text) returns void language plpgsql as $$
begin
  if p_user is null then
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.jwt.claim.sub', '', true);
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', p_user, true);
  end if;
end;
$$;

-- sha256 hex of a background key, as push_background_location hashes it.
create function pg_temp.hash(p text) returns text language sql as $$
  select encode(extensions.digest(convert_to(p, 'UTF8'), 'sha256'), 'hex');
$$;

-- ---- Accounts --------------------------------------------------------------------------------------
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000337a1'),  -- the subject (a plain user)
  ('00000000-0000-0000-0000-0000000337a2'),  -- a driver (partner)
  ('00000000-0000-0000-0000-0000000337a3'),  -- an opted-in passenger
  ('00000000-0000-0000-0000-0000000337c1'),  -- God View admin, EDIT
  ('00000000-0000-0000-0000-0000000337c2')   -- a plain non-admin
on conflict do nothing;
insert into public.profiles (id, name) values
  ('00000000-0000-0000-0000-0000000337a1', 'Subject User'),
  ('00000000-0000-0000-0000-0000000337a2', 'Driver'),
  ('00000000-0000-0000-0000-0000000337a3', 'Passenger'),
  ('00000000-0000-0000-0000-0000000337c1', 'God View Admin'),
  ('00000000-0000-0000-0000-0000000337c2', 'Non Admin')
on conflict (id) do update set name = excluded.name;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000337c1', 'admin-god-view', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name) values ('00000000-0000-0000-0000-0000000337a2', 'Driver');
update public.profiles set location_checkins = true where id = '00000000-0000-0000-0000-0000000337a3';

-- A background token for each account that reports (key, location_always, no
-- location yet so the throttle lets the first report through).
insert into public.push_tokens (profile_id, platform, device_key, bg_key_hash, location_always, last_lat, last_lng) values
  ('00000000-0000-0000-0000-0000000337a1', 'android', 'dev-a1', pg_temp.hash(repeat('a1', 24)), true, 3.1, 101.6),
  ('00000000-0000-0000-0000-0000000337a2', 'android', 'dev-a2', pg_temp.hash(repeat('a2', 24)), true, 3.1, 101.6),
  ('00000000-0000-0000-0000-0000000337a3', 'android', 'dev-a3', pg_temp.hash(repeat('a3', 24)), true, 3.1, 101.6);

-- ---- 1. The admin target page is registered -------------------------------------------------------
do $$
begin
  perform pg_temp.check(exists (select 1 from public.admin_table_pages
      where target = 'rpc:admin_safety_location_set' and page = 'admin-god-view'),
    'the set RPC is on the God View page');
end $$;

-- ---- 2. A non-admin cannot open a case ------------------------------------------------------------
do $$
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000337c2');
  begin
    perform public.admin_safety_location_set('00000000-0000-0000-0000-0000000337a1', true, 'Report of harassment', 'modal');
    raise exception 'FAILED: a non-admin opened a safety case';
  exception when insufficient_privilege then null;
  end;
  perform pg_temp.check(not exists (select 1 from public.safety_location_cases
      where user_id = '00000000-0000-0000-0000-0000000337a1'),
    'no case was created by the non-admin');
end $$;

-- ---- 3. Opening needs a reason --------------------------------------------------------------------
do $$
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000337c1');
  begin
    perform public.admin_safety_location_set('00000000-0000-0000-0000-0000000337a1', true, '   ', 'modal');
    raise exception 'FAILED: a case was opened with no reason';
  exception when invalid_parameter_value then null;
  end;
end $$;

-- ---- 4. Admin opens the case; audit row written; still NOT acked ----------------------------------
do $$
declare r jsonb;
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000337c1');
  r := public.admin_safety_location_set('00000000-0000-0000-0000-0000000337a1', true, 'Report of harassment', 'modal');
  perform pg_temp.check((r ->> 'enabled')::boolean and r ->> 'disclosure_style' = 'modal'
                        and (r ->> 'notified')::boolean is false,
    'the case is open, modal, not yet notified');
  perform pg_temp.check(exists (select 1 from public.admin_audit_log
      where action = 'safety_location.set' and target_profile_id = '00000000-0000-0000-0000-0000000337a1'
        and actor_id = '00000000-0000-0000-0000-0000000337c1'),
    'an audit row was written');
  -- The detailed reason is kept internally, never generic.
  perform pg_temp.check((select reason from public.safety_location_cases
      where user_id = '00000000-0000-0000-0000-0000000337a1') = 'Report of harassment',
    'the admin reason is stored');
  -- The admin read RPC surfaces notified_at (null until the app acks).
  r := public.admin_safety_location_state('00000000-0000-0000-0000-0000000337a1');
  perform pg_temp.check((r ->> 'enabled')::boolean and r ->> 'reason' = 'Report of harassment'
                        and r ->> 'notified_at' is null and (r ->> 'notified')::boolean is false,
    'the admin state shows the case not yet shown to the user');
end $$;

-- ---- 5. THE HARD RULE: enabled but not acked → no report is kept ----------------------------------
do $$
begin
  perform pg_temp.check(public.background_checkin_allowed('00000000-0000-0000-0000-0000000337a1') is false,
    'enabled-but-not-acked is NOT allowed a background report');
  perform pg_temp.check(public.push_background_location(repeat('a1', 24), 3.2, 101.7) = 0,
    'push_background_location keeps nothing before the ack');
  perform pg_temp.check(not exists (select 1 from public.user_location_history
      where user_id = '00000000-0000-0000-0000-0000000337a1'),
    'nothing recorded for the subject before disclosure');
end $$;

-- ---- 6. The user's app reads a generic state and acks ---------------------------------------------
do $$
declare s jsonb;
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000337a1');
  s := public.safety_location_state();
  perform pg_temp.check((s ->> 'active')::boolean and s ->> 'style' = 'modal'
                        and s ->> 'reason' = 'a safety review',
    'the subject sees an active, generic state: ' || coalesce(s::text, 'null'));
  -- The ack (the app has shown the modal) sets notified_at.
  s := public.safety_location_ack();
  perform pg_temp.check((s ->> 'notified')::boolean, 'ack marks the case notified');
  -- The admin now sees when the user was shown it.
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000337c1');
  perform pg_temp.check((public.admin_safety_location_state('00000000-0000-0000-0000-0000000337a1') ->> 'notified_at') is not null,
    'the admin state now shows notified_at');
end $$;

-- ---- 7. After the ack → reports are kept ----------------------------------------------------------
do $$
begin
  update public.push_tokens set located_at = null where profile_id = '00000000-0000-0000-0000-0000000337a1';
  perform pg_temp.check(public.background_checkin_allowed('00000000-0000-0000-0000-0000000337a1'),
    'after ack the subject is allowed a background report');
  perform pg_temp.check(public.push_background_location(repeat('a1', 24), 3.2, 101.7) = 1,
    'push_background_location keeps a report after the ack');
  perform pg_temp.check(exists (select 1 from public.user_location_history
      where user_id = '00000000-0000-0000-0000-0000000337a1'),
    'the position is recorded after disclosure');
end $$;

-- ---- 8. Closing the case → refused again ----------------------------------------------------------
do $$
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000337c1');
  perform public.admin_safety_location_set('00000000-0000-0000-0000-0000000337a1', false, null, 'modal');
  perform pg_temp.check(public.background_checkin_allowed('00000000-0000-0000-0000-0000000337a1') is false,
    'a closed case allows no background report');
  update public.push_tokens set located_at = null where profile_id = '00000000-0000-0000-0000-0000000337a1';
  perform pg_temp.check(public.push_background_location(repeat('a1', 24), 3.3, 101.8) = 0,
    'push_background_location keeps nothing once the case is closed');
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000337a1');
  perform pg_temp.check(public.safety_location_state() is null, 'the subject sees no active case once closed');
end $$;

-- ---- 9. Reopening clears the ack (fresh disclosure required) --------------------------------------
do $$
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000337c1');
  perform public.admin_safety_location_set('00000000-0000-0000-0000-0000000337a1', true, 'New report', 'banner');
  perform pg_temp.check((select notified_at is null from public.safety_location_cases
      where user_id = '00000000-0000-0000-0000-0000000337a1'),
    'reopening clears notified_at so the app must disclose again');
  perform pg_temp.check(public.background_checkin_allowed('00000000-0000-0000-0000-0000000337a1') is false,
    'a reopened, un-acked case allows no report');
  -- The style can change any time; it is live.
  perform pg_temp.check((select disclosure_style from public.safety_location_cases
      where user_id = '00000000-0000-0000-0000-0000000337a1') = 'banner', 'the style changed to banner');
end $$;

-- ---- 10. Drivers and opted-in passengers are unaffected -------------------------------------------
do $$
begin
  -- The driver: allowed as before, with no safety case at all.
  perform pg_temp.check(public.background_checkin_allowed('00000000-0000-0000-0000-0000000337a2'),
    'a driver is allowed a background report regardless of any safety case');
  perform pg_temp.check(public.push_background_location(repeat('a2', 24), 3.2, 101.7) = 1,
    'the driver report is kept');
  -- The passenger: blocked until the admin switch is on, then allowed (opted in).
  perform pg_temp.check(public.background_checkin_allowed('00000000-0000-0000-0000-0000000337a3') is false,
    'an opted-in passenger is blocked while the admin switch is off');
  update public.app_settings set value = '{"passengers": true}' where key = 'location_checkins';
  perform pg_temp.check(public.background_checkin_allowed('00000000-0000-0000-0000-0000000337a3'),
    'an opted-in passenger is allowed once the admin switch is on');
end $$;

-- ---- 11. God View device breakdown; gating --------------------------------------------------------
do $$
declare d jsonb;
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000337c1');
  d := public.god_view_devices('00000000-0000-0000-0000-0000000337a1');
  perform pg_temp.check(jsonb_array_length(d -> 'devices') >= 1, 'god_view_devices lists the subject''s device');
  perform pg_temp.check((d -> 'devices' -> 0 ->> 'platform') = 'android', 'the device platform is given');
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000337c2');
  begin
    perform public.god_view_devices('00000000-0000-0000-0000-0000000337a1');
    raise exception 'FAILED: a non-admin read the devices';
  exception when insufficient_privilege then null;
  end;
end $$;

-- ---- 12. Freshness: a history row newer than the push token refreshes the map ---------------------
do $$
declare v jsonb;
begin
  perform pg_temp.as_caller(null);
  -- The subject's token last reported long ago; an open-app history row is fresh.
  update public.push_tokens set located_at = now() - interval '18 hours', located_bg = false, last_lat = 3.0, last_lng = 101.0
   where profile_id = '00000000-0000-0000-0000-0000000337a1';
  delete from public.safety_location_cases where user_id = '00000000-0000-0000-0000-0000000337a1';
  delete from public.user_location_history where user_id = '00000000-0000-0000-0000-0000000337a1';
  insert into public.user_location_history (user_id, latitude, longitude, captured_at)
  values ('00000000-0000-0000-0000-0000000337a1', 3.5, 101.9, now());
  -- god_view_people should show the fresher history position, not "last known".
  perform pg_temp.check(exists (
    select 1 from public.god_view_people(null, false, null, '00000000-0000-0000-0000-0000000337a1', false, null, null) g
     where g.status <> 'last_known' and round(g.lat::numeric, 1) = 3.5),
    'a fresh history row makes the subject live at the newer position');
end $$;

do $$ begin raise notice 'ALL SAFETY LOCATION 0337 CHECKS PASSED'; end $$;

rollback;
