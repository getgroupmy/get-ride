-- ============================================================================
-- Regression test for migrations 0179 and 0180: sign-in switches, and one
-- device per account with the newest sign-in winning (admins exempt).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/one_device.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Requests are simulated by setting the claims PostgREST would set; the
-- same flow was checked through a real PostgREST with signed tokens.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000180a1'),
  ('00000000-0000-0000-0000-0000000180b1')
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000180%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values ('00000000-0000-0000-0000-0000000180b1', '*', 'edit');

-- u1's old phone (A, signed in ten minutes ago) and new phone (B, now);
-- the admin's two devices (E, F).
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('00000000-0000-0000-0000-00000018005a', '00000000-0000-0000-0000-0000000180a1', now() - interval '10 minutes', now()),
  ('00000000-0000-0000-0000-00000018005e', '00000000-0000-0000-0000-0000000180b1', now(), now()),
  ('00000000-0000-0000-0000-00000018005f', '00000000-0000-0000-0000-0000000180b1', now(), now());

create function pg_temp.as_session(p_user text, p_session text, p_path text default '/profiles')
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'session_id', p_session)::text, true);
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
  c jsonb;
begin
  -- Shipped off, all four; anon may read them.
  c := public.sign_in_config();
  if c <> '{"passkeyWeb": false, "passkeyAndroid": false, "passkeyIos": false, "oneDevice": false}'::jsonb then
    raise exception 'switches ship off: %', c;
  end if;
  if not has_function_privilege('anon', 'public.sign_in_config()', 'execute') then
    raise exception 'the sign-in screen reads the switches before anybody signs in';
  end if;

  -- Off: claiming records nothing, the guard lets everything through.
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000180a1', '00000000-0000-0000-0000-00000018005a');
  if (public.claim_session('phoneA')->>'enforced')::boolean then raise exception 'off: not enforced'; end if;
  if pg_temp.guard_refuses() then raise exception 'off: nothing refused'; end if;
end
$$;

update public.app_settings set value = value || '{"oneDevice": true}' where key = 'sign_in';

do $$
begin
  -- A claims, then B signs in on a new phone: B may work before it claims.
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000180a1', '00000000-0000-0000-0000-00000018005a');
  perform public.claim_session('phoneA', 'Phone A', 'android', '1.4.8');
  update public.active_sessions set claimed_at = now() - interval '5 seconds' where user_id = '00000000-0000-0000-0000-0000000180a1';
  if pg_temp.guard_refuses() then raise exception 'A works after claiming'; end if;
  insert into auth.sessions (id, user_id, created_at, updated_at) values
    ('00000000-0000-0000-0000-00000018005b', '00000000-0000-0000-0000-0000000180a1', now(), now());

  perform pg_temp.as_session('00000000-0000-0000-0000-0000000180a1', '00000000-0000-0000-0000-00000018005b');
  if pg_temp.guard_refuses() then raise exception 'a new sign-in gets its moment to claim'; end if;
  perform public.claim_session('phoneB', 'Phone B', 'ios', '1.4.8');

  -- The newest wins: A is refused everywhere but where it asks, and can't refresh.
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000180a1', '00000000-0000-0000-0000-00000018005a');
  if not pg_temp.guard_refuses() then raise exception 'A is refused once B signed in'; end if;
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000180a1', '00000000-0000-0000-0000-00000018005a', '/rpc/session_is_current');
  if pg_temp.guard_refuses() then raise exception 'A may still ask whether it is current'; end if;
  if public.session_is_current() then raise exception 'and is told it is not'; end if;
  if exists (select 1 from auth.sessions where id = '00000000-0000-0000-0000-00000018005a') then
    raise exception 'A''s sign-in can no longer be refreshed';
  end if;

  -- On launch, claiming only if unclaimed never takes over.
  perform public.claim_session('phoneA', p_only_if_unclaimed => true);
  if (select session_id from public.active_sessions where user_id = '00000000-0000-0000-0000-0000000180a1')
     <> '00000000-0000-0000-0000-00000018005b' then
    raise exception 'a launch claim must not steal the account back';
  end if;

  -- Admins: two devices, nothing recorded.
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000180b1', '00000000-0000-0000-0000-00000018005e');
  perform public.claim_session('laptop');
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000180b1', '00000000-0000-0000-0000-00000018005f');
  perform public.claim_session('gateway');
  if pg_temp.guard_refuses() then raise exception 'an admin is not held to one device'; end if;
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000180b1', '00000000-0000-0000-0000-00000018005e');
  if pg_temp.guard_refuses() then raise exception 'an admin keeps both devices'; end if;
  if exists (select 1 from public.active_sessions where user_id = '00000000-0000-0000-0000-0000000180b1') then
    raise exception 'nothing is recorded for an admin';
  end if;

  -- The admin signs u1 out everywhere: B is refused too.
  perform public.admin_sign_out_everywhere('00000000-0000-0000-0000-0000000180a1');
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000180a1', '00000000-0000-0000-0000-00000018005b');
  if not pg_temp.guard_refuses() then raise exception 'signed out everywhere means B too'; end if;

  -- Only an admin may do that, or change the switches.
  begin
    perform public.admin_sign_out_everywhere('00000000-0000-0000-0000-0000000180b1');
    raise exception 'a member signed somebody else out';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.set_sign_in_config('{"oneDevice": false}');
    raise exception 'a member changed the switches';
  exception when insufficient_privilege then null;
  end;

  -- Turned off: everybody is let go.
  perform pg_temp.as_session('00000000-0000-0000-0000-0000000180b1', '00000000-0000-0000-0000-00000018005e');
  perform public.set_sign_in_config('{"oneDevice": false, "passkeyIos": true}');
  if exists (select 1 from public.active_sessions) then raise exception 'off clears every recorded session'; end if;
  if not (public.sign_in_config()->>'passkeyIos')::boolean then raise exception 'the passkey switch saved'; end if;

  -- The guard never fails a request it can't read.
  perform set_config('request.jwt.claims', 'not json', true);
  if pg_temp.guard_refuses() then raise exception 'unreadable claims pass'; end if;

  if has_function_privilege('anon', 'public.claim_session(text, text, text, text, boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.one_device_on()', 'execute') then
    raise exception 'grants';
  end if;
end
$$;

rollback;
