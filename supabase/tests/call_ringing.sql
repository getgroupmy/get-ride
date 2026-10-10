-- ============================================================================
-- Regression test for migration 0134: a device registers what its build can
-- do, and a ride call that stops ringing unanswered tells the callee.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/call_ringing.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================

do $$
declare
  m jsonb;
begin
  m := public.ride_call_end_message('ringing', 'missed', '00000000-0000-0000-0000-0000000134c1',
                                    '00000000-0000-0000-0000-0000000134d1', ' Aina ', 'rider');
  if m->>'title' <> 'Missed call' or m->>'body' <> 'Aina called about your ride.'
     or m->'data'->>'type' <> 'ride_call_end' or m->'data'->>'role' <> 'partner'
     or m->'data'->>'call_id' <> '00000000-0000-0000-0000-0000000134c1' then
    raise exception 'FAILED: missed call message: %', m;
  end if;
  m := public.ride_call_end_message('ringing', 'cancelled', gen_random_uuid(), gen_random_uuid(), null, 'partner');
  if m->>'body' <> 'Someone called about your ride.' or m->'data'->>'role' <> 'rider' then
    raise exception 'FAILED: cancelled call message: %', m;
  end if;
  if public.ride_call_end_message('ringing', 'declined', gen_random_uuid(), gen_random_uuid(), 'A', 'rider') is not null
     or public.ride_call_end_message('ringing', 'answered', gen_random_uuid(), gen_random_uuid(), 'A', 'rider') is not null
     or public.ride_call_end_message('answered', 'ended', gen_random_uuid(), gen_random_uuid(), 'A', 'rider') is not null then
    raise exception 'FAILED: only an unanswered call is a missed call';
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'trg_ride_calls_end_push') then
    raise exception 'FAILED: trg_ride_calls_end_push is missing';
  end if;
  if has_function_privilege('authenticated', 'public.notify_ride_call_end_push()', 'execute')
     or has_function_privilege('anon', 'public.notify_ride_call_end_push()', 'execute')
     or has_function_privilege('anon', 'public.push_register_device(text, text, text, text[])', 'execute')
     or not has_function_privilege('authenticated', 'public.push_register_device(text, text, text, text[])', 'execute') then
    raise exception 'FAILED: grants on the 0134 functions';
  end if;
end
$$;

begin;

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000134a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000134a1') on conflict do nothing;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000134a1","role":"authenticated"}', true);
set local role authenticated;

-- Unknown capabilities are dropped; duplicates collapse.
select public.push_register_device('tok-134', 'android', null, array['call_ui', 'teleport', 'call_ui']);
reset role;
do $$
begin
  if (select capabilities from public.push_tokens where token = 'tok-134') <> array['call_ui'] then
    raise exception 'FAILED: capabilities stored as %', (select capabilities from public.push_tokens where token = 'tok-134');
  end if;
end
$$;

-- The old registration (Expo, older builds) leaves the capabilities alone.
set local role authenticated;
select public.push_register_token('tok-134', 'android', 'Pixel');
reset role;
do $$
begin
  if (select capabilities from public.push_tokens where token = 'tok-134') <> array['call_ui']
     or (select device_name from public.push_tokens where token = 'tok-134') <> 'Pixel' then
    raise exception 'FAILED: push_register_token must not reset capabilities';
  end if;
end
$$;

-- Registering again without the capability takes it away (a downgraded build).
set local role authenticated;
select public.push_register_device('tok-134', 'android', null, null);
reset role;
do $$
begin
  if (select capabilities from public.push_tokens where token = 'tok-134') <> '{}'::text[] then
    raise exception 'FAILED: re-registering replaces the capabilities';
  end if;
end
$$;

rollback;

select 'call_ringing: all passed';
