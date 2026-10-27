-- ============================================================================
-- Regression test for migration 0298: an admin allows a chosen account
-- more than one device; past the allowance, the device that signed in
-- longest ago is signed out.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/device_allowance_0298.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up accounts only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000298a1'),  -- the account allowed more
  ('00000000-0000-0000-0000-0000000298c1'),  -- admin, EDIT on Users
  ('00000000-0000-0000-0000-0000000298c2'),  -- admin, READ on Users
  ('00000000-0000-0000-0000-0000000298c3')   -- full admin
on conflict do nothing;
insert into public.profiles (id, name) select id, 'Fleet Office' from auth.users
 where id::text like '00000000-0000-0000-0000-0000000298%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000298c1', 'admin-users', 'edit'),
  ('00000000-0000-0000-0000-0000000298c2', 'admin-users', 'read'),
  ('00000000-0000-0000-0000-0000000298c3', '*', 'edit')
on conflict do nothing;

-- Four tablets, signed in one after another.
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('00000000-0000-0000-0000-00000029800a', '00000000-0000-0000-0000-0000000298a1', now() - interval '40 minutes', now()),
  ('00000000-0000-0000-0000-00000029800b', '00000000-0000-0000-0000-0000000298a1', now() - interval '30 minutes', now()),
  ('00000000-0000-0000-0000-00000029800c', '00000000-0000-0000-0000-0000000298a1', now() - interval '20 minutes', now()),
  ('00000000-0000-0000-0000-00000029800d', '00000000-0000-0000-0000-0000000298a1', now() - interval '10 minutes', now());

update public.app_settings set value = value || '{"oneDevice": true}' where key = 'sign_in';

create function pg_temp.as_session(p_user text, p_session text, p_path text default '/profiles')
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'session_id', p_session)::text, true);
  perform set_config('request.jwt.claim.sub', p_user, true);
  perform set_config('request.path', p_path, true);
end;
$$;

create function pg_temp.guard_refuses() returns boolean language plpgsql as $$
begin
  perform public.request_guard();
  return false;
exception when sqlstate 'PT401' then
  return true;
end;
$$;

do $$
declare
  u constant text := '00000000-0000-0000-0000-0000000298a1';
  c jsonb;
begin
  -- One device by default: tablet A claims through 0180's row.
  perform pg_temp.as_session(u, '00000000-0000-0000-0000-00000029800a');
  c := public.claim_session('tabA', 'Tablet A', 'android', '1.4.10');
  if (c->>'allowed')::int <> 1 then raise exception 'FAILED: one by default: %', c; end if;
  if not exists (select 1 from public.active_sessions where user_id = u::uuid) then
    raise exception 'FAILED: one device is recorded as before';
  end if;

  -- A read-only admin can't change it; the edit admin allows 3.
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000298c2', '00000000-0000-0000-0000-0000000298f2');
  begin
    perform public.admin_device_allowance_set(u::uuid, 3, 'Office tablets');
    raise exception 'FAILED: a read-only admin changed the allowance';
  exception when insufficient_privilege then null;
  end;
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000298c1', '00000000-0000-0000-0000-0000000298f1');
  begin
    perform public.admin_device_allowance_set(u::uuid, 11);
    raise exception 'FAILED: 11 devices were allowed';
  exception when invalid_parameter_value then null;
  end;
  perform public.admin_device_allowance_set(u::uuid, 3, '  Office tablets  ');
  if (select reason from public.device_allowances where user_id = u::uuid) <> 'Office tablets' then
    raise exception 'FAILED: the reason is kept, trimmed';
  end if;
  if exists (select 1 from public.active_sessions where user_id = u::uuid)
     or not exists (select 1 from public.account_devices
                     where user_id = u::uuid and session_id = '00000000-0000-0000-0000-00000029800a') then
    raise exception 'FAILED: tablet A moved into the list, its old row gone';
  end if;

  -- B and C claim: all three work.
  perform pg_temp.as_session(u, '00000000-0000-0000-0000-00000029800b');
  c := public.claim_session('tabB', 'Tablet B', 'android', '1.4.10');
  if (c->>'allowed')::int <> 3 or not (c->>'current')::boolean then raise exception 'FAILED: B claims: %', c; end if;
  perform pg_temp.as_session(u, '00000000-0000-0000-0000-00000029800c');
  perform public.claim_session('tabC', 'Tablet C', 'android', '1.4.10');
  perform pg_temp.as_session(u, '00000000-0000-0000-0000-00000029800a');
  if pg_temp.guard_refuses() then raise exception 'FAILED: A still works with three allowed'; end if;
  perform pg_temp.as_session(u, '00000000-0000-0000-0000-00000029800b');
  if pg_temp.guard_refuses() then raise exception 'FAILED: B works'; end if;

  -- A fourth (D): A, signed in longest ago, is signed out; B, C and D stay.
  perform pg_temp.as_session(u, '00000000-0000-0000-0000-00000029800d');
  c := public.claim_session('tabD', 'Tablet D', 'android', '1.4.10');
  if (c->>'signed_out')::int <> 1 then raise exception 'FAILED: one device signed out: %', c; end if;
  perform pg_temp.as_session(u, '00000000-0000-0000-0000-00000029800a');
  if not pg_temp.guard_refuses() then raise exception 'FAILED: A is refused once D signed in'; end if;
  if exists (select 1 from auth.sessions where id = '00000000-0000-0000-0000-00000029800a') then
    raise exception 'FAILED: A can no longer refresh';
  end if;
  -- On launch A can't take a place back.
  c := public.claim_session('tabA', p_only_if_unclaimed => true);
  if (c->>'current')::boolean then raise exception 'FAILED: a launch claim took a place back: %', c; end if;
  perform pg_temp.as_session(u, '00000000-0000-0000-0000-00000029800b');
  if pg_temp.guard_refuses() then raise exception 'FAILED: B kept its place'; end if;
  if (select count(*) from public.account_devices where user_id = u::uuid) <> 3 then
    raise exception 'FAILED: three places';
  end if;

  -- The admin's list.
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000298c2', '00000000-0000-0000-0000-0000000298f2');
  if (select in_use from public.admin_device_allowances() where user_id = u::uuid) <> 3 then
    raise exception 'FAILED: the list shows three in use';
  end if;

  -- Signing a device out is for full admins, as "Sign out all devices" is.
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000298c1', '00000000-0000-0000-0000-0000000298f1');
  begin
    perform public.admin_sign_out_device(u::uuid, '00000000-0000-0000-0000-00000029800b');
    raise exception 'FAILED: a Users editor signed a device out';
  exception when insufficient_privilege then null;
  end;
  -- A full admin signs B out: B is refused, C still works.
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000298c3', '00000000-0000-0000-0000-0000000298f3');
  if not public.admin_sign_out_device(u::uuid, '00000000-0000-0000-0000-00000029800b') then
    raise exception 'FAILED: B was signed out';
  end if;
  perform pg_temp.as_session(u, '00000000-0000-0000-0000-00000029800b');
  if not pg_temp.guard_refuses() then raise exception 'FAILED: B is refused'; end if;
  perform pg_temp.as_session(u, '00000000-0000-0000-0000-00000029800c');
  if pg_temp.guard_refuses() then raise exception 'FAILED: C still works'; end if;

  -- Back to one: the newest (D) stays, recorded as 0180 does; C is refused.
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000298c1', '00000000-0000-0000-0000-0000000298f1');
  perform public.admin_device_allowance_set(u::uuid, 1);
  if exists (select 1 from public.device_allowances where user_id = u::uuid)
     or exists (select 1 from public.account_devices where user_id = u::uuid) then
    raise exception 'FAILED: back to the default';
  end if;
  if (select session_id from public.active_sessions where user_id = u::uuid)
     <> '00000000-0000-0000-0000-00000029800d' then
    raise exception 'FAILED: the newest device stays';
  end if;
  perform pg_temp.as_session(u, '00000000-0000-0000-0000-00000029800c');
  if not pg_temp.guard_refuses() then raise exception 'FAILED: C is refused at one device'; end if;

  -- Sign out everywhere with an allowance: every device refused.
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000298c1', '00000000-0000-0000-0000-0000000298f1');
  perform public.admin_device_allowance_set(u::uuid, 2);
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000298c3', '00000000-0000-0000-0000-0000000298f3');
  perform public.admin_sign_out_everywhere(u::uuid);
  perform pg_temp.as_session(u, '00000000-0000-0000-0000-00000029800d');
  if not pg_temp.guard_refuses() then raise exception 'FAILED: signed out everywhere means D too'; end if;

  -- Turned off (a full admin): everybody is let go.
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000298c3', '00000000-0000-0000-0000-0000000298f3');
  perform public.set_sign_in_config('{"oneDevice": false}');
  if exists (select 1 from public.account_devices) then raise exception 'FAILED: off clears the lists'; end if;

  -- The tables are read by admins only; the functions are not for anon.
  if has_function_privilege('anon', 'public.admin_device_allowance_set(uuid, integer, text)', 'execute')
     or has_function_privilege('authenticated', 'public.device_trim(uuid, integer)', 'execute')
     or has_function_privilege('authenticated', 'public.device_allowance(uuid)', 'execute') then
    raise exception 'FAILED: grants';
  end if;
end
$$;

rollback;

select 'device_allowance_0298: all passed';
