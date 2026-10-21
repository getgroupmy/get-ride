-- ============================================================================
-- Guard: nobody signed out or signed in reaches net.* (pg_net's HTTP calls)
-- through the exposed schemas.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/net_http_callers.sql
--
-- net itself is not an exposed schema (Data API: public, graphql_public), so
-- the only ways in are code in those schemas that calls net.*:
--   1. a function anon or authenticated may run (an RPC);
--   2. a view in an exposed schema that reads net.*;
--   3. a trigger on a table a client writes to. The push triggers below are
--      known and reviewed: they call send_push_webhook, which posts to the
--      app's own send-push function only. A new one fails here until it is
--      reviewed and added to the list.
--
-- Read-only. A failed assertion raises an exception.
-- ============================================================================
do $$
declare
  r record;
  v_known text[] := array[
    'ride_requests.trg_ride_request_push',
    'ride_requests.trg_ride_requests_expired_push',
    'wallet_transfer_requests.trg_wallet_transfer_request_push',
    'wallet_transfer_requests.trg_wallet_transfer_response_push',
    'ride_calls.trg_ride_calls_push',
    'ride_calls.trg_ride_calls_end_push'
  ];
begin
  -- 1. No function in an exposed schema that calls net.* (or the push
  --    webhook) can be run by a client.
  for r in
    select p.oid::regprocedure as fn, role
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     cross join unnest(array['anon', 'authenticated']) as role
     where n.nspname in ('public', 'graphql_public')
       and p.prokind = 'f'
       and p.prorettype <> 'trigger'::regtype
       and (p.prosrc ~* '\mnet\.' or p.prosrc ~* 'send_push_webhook')
       and has_function_privilege(role, p.oid, 'execute')
  loop
    raise exception '% calls net.* and % can run it: revoke execute from anon, authenticated', r.fn, r.role;
  end loop;

  -- 2. No view in an exposed schema reads net.*.
  for r in
    select c.oid::regclass as view
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'graphql_public')
       and c.relkind in ('v', 'm')
       and pg_get_viewdef(c.oid) ~* '\mnet\.'
  loop
    raise exception 'view % reads net.*: move it out of the exposed schemas', r.view;
  end loop;

  -- 3. Triggers that reach net.* fire only where reviewed.
  for r in
    select format('%s.%s', c.relname, t.tgname) as trg, p.oid::regprocedure as fn
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
      join pg_proc p on p.oid = t.tgfoid
     where not t.tgisinternal
       and n.nspname in ('public', 'graphql_public')
       and (p.prosrc ~* '\mnet\.' or p.prosrc ~* 'send_push_webhook')
  loop
    if not r.trg = any (v_known) then
      raise exception 'trigger % (%) reaches net.*: review it, then add it to the list in this test', r.trg, r.fn;
    end if;
  end loop;
end $$;
