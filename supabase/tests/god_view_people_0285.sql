-- ============================================================================
-- Regression test for migration 0285: which people a sub-admin's God View
-- shows. Only these people sees just those (wherever they are); Hide these
-- people takes them off the map, the list, the search and the Movement trail,
-- in a region and with Everywhere; Nobody sees no one; a full admin is not
-- limited; only a full admin or an EDIT grant on Sub-admins writes the lists
-- (never their own), people_mode is not written past the RPC, and a change
-- is logged.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/god_view_people_0285.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('anon', 'public.admin_god_view_people_save(uuid, text, uuid[], uuid[])', 'execute')
     or has_function_privilege('anon', 'public.admin_god_view_people_get(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.god_view_people_rule()', 'execute')
     or has_function_privilege('authenticated', 'public.admin_god_view_people_state(uuid)', 'execute')
     or has_table_privilege('authenticated', 'public.admin_god_view_people', 'insert')
     or has_table_privilege('authenticated', 'public.admin_god_view_people', 'update')
     or has_table_privilege('authenticated', 'public.admin_god_view_people', 'delete')
     or not has_function_privilege('authenticated', 'public.admin_god_view_people_save(uuid, text, uuid[], uuid[])', 'execute') then
    raise exception 'FAILED: 0285 grants';
  end if;
end
$$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000285a1', '60128500001'),  -- full admin
  ('00000000-0000-0000-0000-0000000285a2', '60128500002'),  -- God View, North, Only f1 and f3
  ('00000000-0000-0000-0000-0000000285a3', '60128500003'),  -- God View, North, hide f2
  ('00000000-0000-0000-0000-0000000285a4', '60128500004'),  -- God View, North, Nobody
  ('00000000-0000-0000-0000-0000000285a5', '60128500005'),  -- God View, Everywhere, hide d1
  ('00000000-0000-0000-0000-0000000285a6', '60128500006'),  -- God View edit + a page that is not Sub-admins
  ('00000000-0000-0000-0000-0000000285a7', '60128500007'),  -- God View + Sub-admins EDIT, not full
  ('00000000-0000-0000-0000-0000000285a8', '60128500008'),  -- Sub-admins READ
  ('00000000-0000-0000-0000-0000000285d1', '60128500011'),  -- partner online, North
  ('00000000-0000-0000-0000-0000000285f1', '60128500021'),  -- user, app open, North
  ('00000000-0000-0000-0000-0000000285f2', '60128500022'),  -- user, app open, North
  ('00000000-0000-0000-0000-0000000285f3', '60128500023')   -- user, app open, far away
on conflict do nothing;
insert into public.profiles (id, name, phone)
select id, 'GV285 ' || right(id::text, 2), '+' || phone from auth.users
 where id::text like '00000000-0000-0000-0000-0000000285%'
on conflict (id) do update set name = excluded.name, phone = excluded.phone;

insert into public.admin_access (profile_id, page, access_level, region) values
  ('00000000-0000-0000-0000-0000000285a1', '*', 'edit', null),
  ('00000000-0000-0000-0000-0000000285a2', 'admin-god-view', 'read', '{"country": "Testland 285", "state": "North 285"}'),
  ('00000000-0000-0000-0000-0000000285a3', 'admin-god-view', 'read', '{"country": "Testland 285", "state": "North 285"}'),
  ('00000000-0000-0000-0000-0000000285a4', 'admin-god-view', 'read', '{"country": "Testland 285", "state": "North 285"}'),
  ('00000000-0000-0000-0000-0000000285a5', 'admin-god-view', 'read', '{"everywhere": true}'),
  ('00000000-0000-0000-0000-0000000285a6', 'admin-god-view', 'edit', null),
  ('00000000-0000-0000-0000-0000000285a6', 'admin-sub-admins', 'edit', null),
  ('00000000-0000-0000-0000-0000000285a7', 'admin-god-view', 'read', '{"country": "Testland 285", "state": "North 285"}'),
  ('00000000-0000-0000-0000-0000000285a7', 'admin-settings-sub-admin', 'edit', null),
  ('00000000-0000-0000-0000-0000000285a8', 'admin-settings-sub-admin', 'read', null)
on conflict (profile_id, page) do update set region = excluded.region, access_level = excluded.access_level;

-- North 285 has a mapped boundary (lng 121..122, lat 13..14).
insert into public.countries (name) values ('Testland 285') on conflict do nothing;
insert into public.states (country, name) values ('Testland 285', 'North 285') on conflict do nothing;
update public.states set boundary_polys = array['((121,13),(122,13),(122,14),(121,14))'::polygon]
 where country = 'Testland 285' and name = 'North 285';

insert into public.partners (id, auth_user_id, name, phone, status, plate, vehicle, vehicle_type) values
  ('00000000-0000-0000-0000-0000000285e1', '00000000-0000-0000-0000-0000000285d1', 'Hafiz 285', '60128500011',
   'approved', 'VJK 285', 'Perodua Bezza', 'Car');
insert into public.driver_presence (profile_id, online, lat, lng, updated_at) values
  ('00000000-0000-0000-0000-0000000285d1', true, 13.5, 121.5, now())
on conflict (profile_id) do update set online = excluded.online, lat = excluded.lat, lng = excluded.lng,
                                      updated_at = excluded.updated_at;
insert into public.push_tokens (profile_id, token, last_lat, last_lng, located_at) values
  ('00000000-0000-0000-0000-0000000285f1', 'gv285-f1', 13.4, 121.4, now() - interval '5 minutes'),
  ('00000000-0000-0000-0000-0000000285f2', 'gv285-f2', 13.3, 121.3, now() - interval '5 minutes'),
  ('00000000-0000-0000-0000-0000000285f3', 'gv285-f3', 15.5, 123.5, now() - interval '5 minutes');
insert into public.user_location_history (user_id, latitude, longitude, captured_at) values
  ('00000000-0000-0000-0000-0000000285f1', 13.4, 121.4, now() - interval '1 hour'),
  ('00000000-0000-0000-0000-0000000285f2', 13.3, 121.3, now() - interval '1 hour'),
  ('00000000-0000-0000-0000-0000000285f3', 15.5, 123.5, now() - interval '1 hour');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
-- The test people in a snapshot, by their last two characters, sorted.
create or replace function pg_temp.mine(p jsonb) returns text language sql as $$
  select coalesce(string_agg(right(x->>'id', 2), ',' order by right(x->>'id', 2)), '')
    from jsonb_array_elements(p->'people') x where x->>'id' like '00000000-0000-0000-0000-0000000285%'
$$;
create or replace function pg_temp.trail_ok(p uuid) returns boolean language plpgsql as $$
begin
  perform public.god_view_trail(p, now() - interval '2 hours', now());
  return true;
exception when others then
  return false;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.mine(jsonb), pg_temp.trail_ok(uuid) to authenticated;

set local role authenticated;

-- 1. A full admin sets the lists; the change is logged ----------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000285a1');
select pg_temp.check(public.admin_god_view_people_save('00000000-0000-0000-0000-0000000285a2', 'only',
  array['00000000-0000-0000-0000-0000000285f1', '00000000-0000-0000-0000-0000000285f3']::uuid[],
  array['00000000-0000-0000-0000-0000000285f1']::uuid[]) ->> 'mode' = 'only', 'Only these people saved');
select pg_temp.check(public.admin_god_view_people_save('00000000-0000-0000-0000-0000000285a3', 'region', '{}',
  array['00000000-0000-0000-0000-0000000285f2']::uuid[]) ->> 'mode' = 'region', 'a hide list saved');
select pg_temp.check(public.admin_god_view_people_save('00000000-0000-0000-0000-0000000285a4', 'nobody') ->> 'mode' = 'nobody',
  'Nobody saved');
select pg_temp.check(public.admin_god_view_people_save('00000000-0000-0000-0000-0000000285a5', 'region', '{}',
  array['00000000-0000-0000-0000-0000000285d1']::uuid[]) ->> 'mode' = 'region', 'Everywhere with a hide list saved');
do $$
declare g jsonb := public.admin_god_view_people_get('00000000-0000-0000-0000-0000000285a2');
begin
  perform pg_temp.check(jsonb_array_length(g->'people') = 3, 'both lists read back: ' || g::text);
  perform pg_temp.check((select count(*) = 2 from jsonb_array_elements(g->'people') x where x->>'list' = 'only'),
    'the only list read back');
  perform pg_temp.check((select bool_and(x->>'name' like 'GV285 %' and x ? 'phone' and x ? 'display_id')
                           from jsonb_array_elements(g->'people') x), 'each person with name, phone and display id');
  g := public.admin_god_view_people_get('00000000-0000-0000-0000-0000000285a5');
  perform pg_temp.check((g->'people'->0->>'partner')::boolean, 'a partner is marked as one');
end $$;
select pg_temp.check((select count(*) = 5 from public.admin_god_view_people), 'a full admin reads the lists');
-- Saving the same again logs nothing new.
select public.admin_god_view_people_save('00000000-0000-0000-0000-0000000285a4', 'nobody');
select pg_temp.check((select count(*) from public.admin_audit_log where action = 'god_view.people'
                        and target_profile_id::text like '00000000-0000-0000-0000-0000000285%') = 4,
  'each change logged once');
select pg_temp.check((select detail->'after'->>'mode' = 'only' and detail->'before'->>'mode' = 'region'
                        and jsonb_array_length(detail->'after'->'only') = 2
                        and actor_id = '00000000-0000-0000-0000-0000000285a1'
                        from public.admin_audit_log where action = 'god_view.people'
                         and target_profile_id = '00000000-0000-0000-0000-0000000285a2'),
  'the log says who changed what');
select pg_temp.refused($q$select public.admin_god_view_people_save('00000000-0000-0000-0000-0000000285d1', 'nobody')$q$,
  'limiting someone without God View');
select pg_temp.refused($q$select public.admin_god_view_people_save('00000000-0000-0000-0000-0000000285a2', 'some')$q$,
  'an unknown mode');

-- 2. A full admin is not limited --------------------------------------------------------------
select pg_temp.check(pg_temp.mine(public.god_view_snapshot()) = 'd1,f1,f2,f3', 'a full admin sees everyone: '
  || pg_temp.mine(public.god_view_snapshot()));
select pg_temp.check(pg_temp.trail_ok('00000000-0000-0000-0000-0000000285f2'), 'a full admin reads any trail');

-- 3. Only these people: just those, wherever they are -------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000285a2');
select pg_temp.check(pg_temp.mine(public.god_view_snapshot()) = 'f1,f3', 'only the listed people: '
  || pg_temp.mine(public.god_view_snapshot()));
select pg_temp.check(public.god_view_snapshot() ->> 'people_mode' = 'only'
                     and not (public.god_view_snapshot() ->> 'scope_missing')::boolean, 'the snapshot says Only');
select pg_temp.check(pg_temp.mine(public.god_view_snapshot(p_query => 'GV285 f2')) = '', 'an unlisted person is not found');
select pg_temp.check(pg_temp.trail_ok('00000000-0000-0000-0000-0000000285f3'), 'a listed person''s trail, outside the region');
select pg_temp.check(not pg_temp.trail_ok('00000000-0000-0000-0000-0000000285f2'), 'an unlisted person''s trail is refused');
select pg_temp.refused($q$select public.god_view_reveal_phone('00000000-0000-0000-0000-0000000285d1')$q$,
  'an unlisted partner''s phone');
select pg_temp.check((select count(*) = 0 from public.admin_god_view_people), 'a sub-admin reads no lists');

-- 4. Hide these people, in a region -------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000285a3');
select pg_temp.check(pg_temp.mine(public.god_view_snapshot()) = 'd1,f1', 'the region less the hidden: '
  || pg_temp.mine(public.god_view_snapshot()));
select pg_temp.check(pg_temp.mine(public.god_view_snapshot(p_query => 'GV285 f2')) = '', 'a hidden person is not found');
select pg_temp.check(not pg_temp.trail_ok('00000000-0000-0000-0000-0000000285f2'), 'a hidden person''s trail is refused');
select pg_temp.check(pg_temp.trail_ok('00000000-0000-0000-0000-0000000285f1'), 'someone else in the region still is not');
select pg_temp.refused($q$select public.god_view_reveal_phone('00000000-0000-0000-0000-0000000285f2')$q$,
  'a hidden person''s phone');

-- 5. Hide these people, with Everywhere ---------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000285a5');
select pg_temp.check(pg_temp.mine(public.god_view_snapshot()) = 'f1,f2,f3', 'everyone less the hidden: '
  || pg_temp.mine(public.god_view_snapshot()));
select pg_temp.check(not pg_temp.trail_ok('00000000-0000-0000-0000-0000000285d1'), 'a hidden partner''s trail is refused');

-- 6. Nobody -------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000285a4');
select pg_temp.check(pg_temp.mine(public.god_view_snapshot()) = '', 'Nobody sees no one');
select pg_temp.check(public.god_view_snapshot() ->> 'people_mode' = 'nobody', 'the snapshot says Nobody');
select pg_temp.check(pg_temp.mine(public.god_view_snapshot(p_show_offline => true)) = '', 'not at their last known place either');
select pg_temp.check((select count(*) = 0 from public.god_view_unlocated()), 'nor in No location');
select pg_temp.check(not pg_temp.trail_ok('00000000-0000-0000-0000-0000000285f1'), 'Nobody reads no trail');

-- 7. Not on Sub-admins: no reading or writing the lists ------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000285a6');
select pg_temp.refused($q$select public.admin_god_view_people_save('00000000-0000-0000-0000-0000000285a3', 'region')$q$,
  'a sub-admin saving the lists');
select pg_temp.refused($q$select public.admin_god_view_people_get('00000000-0000-0000-0000-0000000285a3')$q$,
  'a sub-admin reading the lists');
select pg_temp.refused($q$insert into public.admin_god_view_people (grant_id, person_id, list)
  select a.id, '00000000-0000-0000-0000-0000000285f2', 'only' from public.admin_access a
   where a.profile_id = '00000000-0000-0000-0000-0000000285a6' and a.page = 'admin-god-view'$q$,
  'a sub-admin writing the table');
select pg_temp.refused($q$delete from public.admin_god_view_people where true$q$, 'a sub-admin deleting from the table');
select pg_temp.refused($q$update public.admin_access set people_mode = null
  where profile_id = '00000000-0000-0000-0000-0000000285a4' and page = 'admin-god-view'$q$,
  'a sub-admin lifting Nobody');
reset role;
select pg_temp.check((select count(*) = 5 from public.admin_god_view_people), 'the lists unchanged');
select pg_temp.check((select people_mode = 'nobody' from public.admin_access
                       where profile_id = '00000000-0000-0000-0000-0000000285a4' and page = 'admin-god-view'),
  'Nobody unchanged');

-- 8. Sub-admins EDIT: saves others' lists, not their own; people_mode only through the RPC ----
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000285a7');
select pg_temp.check(jsonb_array_length(public.admin_god_view_people_get('00000000-0000-0000-0000-0000000285a3')->'people') = 1,
  'a Sub-admins editor reads the lists');
select pg_temp.check(public.admin_god_view_people_save('00000000-0000-0000-0000-0000000285a4', 'region') ->> 'mode' = 'region',
  'a Sub-admins editor saves another sub-admin''s lists');
select pg_temp.refused($q$select public.admin_god_view_people_save('00000000-0000-0000-0000-0000000285a7', 'region',
  '{}', array['00000000-0000-0000-0000-0000000285f1']::uuid[])$q$, 'an editor changing their own God View');
select pg_temp.refused($q$update public.admin_access set people_mode = 'nobody'
  where profile_id = '00000000-0000-0000-0000-0000000285a4' and page = 'admin-god-view'$q$,
  'people_mode written past the RPC');
select pg_temp.refused($q$insert into public.admin_access (profile_id, page, access_level, people_mode)
  values ('00000000-0000-0000-0000-0000000285f3', 'admin-god-view', 'read', 'only')$q$,
  'a grant inserted with people_mode');
update public.admin_access set region = '{"country": "Testland 285"}'
 where profile_id = '00000000-0000-0000-0000-0000000285a3' and page = 'admin-god-view';
select pg_temp.check((select region->>'state' is null from public.admin_access
                       where profile_id = '00000000-0000-0000-0000-0000000285a3' and page = 'admin-god-view'),
  'the page still writes the region');
select pg_temp.as_user('00000000-0000-0000-0000-0000000285a8');
select pg_temp.check(public.admin_god_view_people_get('00000000-0000-0000-0000-0000000285a3') ->> 'mode' = 'region',
  'Sub-admins READ reads the lists');
select pg_temp.refused($q$select public.admin_god_view_people_save('00000000-0000-0000-0000-0000000285a3', 'nobody')$q$,
  'Sub-admins READ saving the lists');
reset role;
select pg_temp.check((select people_mode is null from public.admin_access
                       where profile_id = '00000000-0000-0000-0000-0000000285a4' and page = 'admin-god-view'),
  'Region saved for a4');
select pg_temp.check((select count(*) = 1 and bool_and(detail->'before'->>'mode' = 'nobody')
                        from public.admin_audit_log where action = 'god_view.people'
                         and actor_id = '00000000-0000-0000-0000-0000000285a7'
                         and target_profile_id = '00000000-0000-0000-0000-0000000285a4'),
  'the editor''s change logged');
select pg_temp.check((select people_mode is null from public.admin_access
                       where profile_id = '00000000-0000-0000-0000-0000000285a7' and page = 'admin-god-view')
                     and (select count(*) = 0 from public.admin_god_view_people g join public.admin_access a on a.id = g.grant_id
                           where a.profile_id = '00000000-0000-0000-0000-0000000285a7'),
  'their own grant unchanged');

-- 9. The grant gone: its lists go with it -------------------------------------------------------
delete from public.admin_access where profile_id = '00000000-0000-0000-0000-0000000285a2' and page = 'admin-god-view';
select pg_temp.check((select count(*) = 2 from public.admin_god_view_people), 'a revoked grant''s lists are gone');

select 'god_view_people_0285: all passed';
rollback;
