-- ============================================================================
-- Regression test for migration 0139: an open request expires on its own,
-- and the rider is told.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_request_expiry.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================

do $$
declare
  m jsonb;
begin
  m := public.ride_expired_message('open', 'expired', '00000000-0000-0000-0000-0000000139c1');
  if m->>'title' <> 'No driver found' or m->'data'->>'type' <> 'ride_expired'
     or m->'data'->>'request_id' <> '00000000-0000-0000-0000-0000000139c1' then
    raise exception 'FAILED: expired message: %', m;
  end if;
  if public.ride_expired_message('open', 'cancelled', gen_random_uuid()) is not null
     or public.ride_expired_message('accepted', 'expired', gen_random_uuid()) is not null
     or public.ride_expired_message('open', 'accepted', gen_random_uuid()) is not null then
    raise exception 'FAILED: only an open request that expires is told';
  end if;
  if has_function_privilege('anon', 'public.expire_open_ride_requests()', 'execute')
     or has_function_privilege('authenticated', 'public.expire_open_ride_requests()', 'execute')
     or has_function_privilege('authenticated', 'public.notify_ride_expired_push()', 'execute') then
    raise exception 'FAILED: grants on the 0139 functions';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'trg_ride_requests_expired_push') then
    raise exception 'FAILED: trg_ride_requests_expired_push is missing';
  end if;
end
$$;

begin;

insert into public.ride_requests (id, status, created_at)
values ('00000000-0000-0000-0000-0000000139a1', 'open', now() - interval '8 minutes'),
       ('00000000-0000-0000-0000-0000000139a2', 'open', now() - interval '2 minutes'),
       ('00000000-0000-0000-0000-0000000139a3', 'accepted', now() - interval '20 minutes');

do $$
begin
  perform public.expire_open_ride_requests();
  if (select status from public.ride_requests where id = '00000000-0000-0000-0000-0000000139a1') <> 'expired' then
    raise exception 'FAILED: an open request past 7 minutes should expire';
  end if;
  if (select status from public.ride_requests where id = '00000000-0000-0000-0000-0000000139a2') <> 'open' then
    raise exception 'FAILED: a request still within 7 minutes stays open';
  end if;
  if (select status from public.ride_requests where id = '00000000-0000-0000-0000-0000000139a3') <> 'accepted' then
    raise exception 'FAILED: a taken request is never expired';
  end if;
end
$$;

rollback;

select 'ride_request_expiry: all passed';
