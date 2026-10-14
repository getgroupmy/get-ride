-- ============================================================================
-- Regression test for migration 0184: a session that no longer exists can't
-- take the account back with claim_session, and pin_check locks the account
-- row while it checks (the concurrency itself is shown outside SQL tests: 50
-- simultaneous guesses, 5 checked).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/auth_races.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000184a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000184a1') on conflict do nothing;

-- The new phone (B) is a live session; the old one (A) was deleted by B's
-- sign-in, but its access token still carries its id.
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('00000000-0000-0000-0000-00000018405b', '00000000-0000-0000-0000-0000000184a1', now(), now());

update public.app_settings set value = value || '{"oneDevice": true}' where key = 'sign_in';

create function pg_temp.as_session(p_session text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-0000000184a1', 'role', 'authenticated', 'session_id', p_session)::text, true);
end;
$$;

do $$
declare
  c jsonb;
begin
  perform pg_temp.as_session('00000000-0000-0000-0000-00000018405b');
  c := public.claim_session('phoneB', 'Phone B', 'android', '1.4.8');
  if not (c->>'current')::boolean then
    raise exception 'FAILED: the live session could not claim: %', c;
  end if;

  perform pg_temp.as_session('00000000-0000-0000-0000-00000018405a');
  c := public.claim_session('phoneA', 'Phone A', 'android', '1.4.8');
  if (c->>'current')::boolean then
    raise exception 'FAILED: a deleted session took the account back: %', c;
  end if;
  if (select session_id from public.active_sessions where user_id = '00000000-0000-0000-0000-0000000184a1')
     is distinct from '00000000-0000-0000-0000-00000018405b' then
    raise exception 'FAILED: the claim moved off the live session';
  end if;
  if not exists (select 1 from auth.sessions where id = '00000000-0000-0000-0000-00000018405b') then
    raise exception 'FAILED: the live session was signed out';
  end if;

  -- pin_check takes the account's row lock before comparing.
  if position('for update' in (select prosrc from pg_proc where proname = 'pin_check')) = 0 then
    raise exception 'FAILED: pin_check checks without locking the account';
  end if;
end
$$;

select 'auth_races: all passed';
rollback;
