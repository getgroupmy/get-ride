-- ============================================================================
-- 0157: Bluetooth keeps working when a phone loses signal (Phase D2/D3 fix)
--
-- Each phone advertises a token that changes every 5 minutes, and until now
-- it fetched each new one from the server. A phone without signal could not,
-- so its handshake (and the Bluetooth chat riding on it, 0155) stopped within
-- five minutes of the signal going — exactly when chat over Bluetooth is
-- meant to help.
--
-- get_trip_ble_token() now also hands out the tokens for the next 30 minutes
-- ('ahead': six windows). Both phones derive the same schedule from the same
-- clock, so they keep finding each other offline, and an online phone that
-- refreshes gets the very tokens an offline one is already rotating to.
--
-- Nothing else changes: ble_handshake_proof() still only takes this window's
-- or the last window's token, so a token issued ahead can't be reported
-- early, and a phone offline can't report at all.
--
-- Rollback: re-run get_trip_ble_token from 0155.
-- ============================================================================

-- How many 5-minute windows ahead a ticket carries.
create or replace function public.ble_windows_ahead()
returns int
language sql
immutable
as $$ select 6 $$;

create or replace function public.get_trip_ble_token(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  r public.ride_requests;
  v_side text;
  v_peer text;
  v_secret bytea;
  v_window bigint := public.ble_window();
  s jsonb := public.reliability_ble();
begin
  v_side := public.ble_ride_side(p_request);
  v_peer := case v_side when 'driver' then 'rider' else 'driver' end;
  select * into r from public.ride_requests where id = p_request;
  if not (s->>'enabled')::boolean then
    return jsonb_build_object('enabled', false);
  end if;
  if r.status not in ('accepted', 'arrived') then
    return jsonb_build_object('enabled', true, 'status', r.status);
  end if;
  insert into public.ride_ble_secrets (request_id, secret) values (p_request, gen_random_bytes(32))
  on conflict (request_id) do nothing;
  update public.ride_ble_secrets
     set rider_seen_at = case when v_side = 'rider' then now() else rider_seen_at end,
         driver_seen_at = case when v_side = 'driver' then now() else driver_seen_at end
   where request_id = p_request
  returning secret into v_secret;
  return jsonb_build_object(
    'enabled', true,
    'status', r.status,
    'side', v_side,
    'token', public.ble_token(v_secret, p_request, v_side, v_window),
    'peer_token', public.ble_token(v_secret, p_request, v_peer, v_window),
    'expires_at', to_timestamp((v_window + 1) * 300),
    'ahead', (select jsonb_agg(jsonb_build_object(
                       'token', public.ble_token(v_secret, p_request, v_side, w),
                       'peer_token', public.ble_token(v_secret, p_request, v_peer, w),
                       'expires_at', to_timestamp((w + 1) * 300)) order by w)
                from generate_series(v_window + 1, v_window + public.ble_windows_ahead()) w),
    'chat_key', case when (s->>'chat')::boolean then
                  encode(hmac(convert_to(p_request::text || ':chat', 'UTF8'), v_secret, 'sha256'), 'hex')
                end,
    'settings', s
  );
end;
$$;
revoke execute on function public.get_trip_ble_token(uuid) from public, anon;
grant execute on function public.get_trip_ble_token(uuid) to authenticated;

notify pgrst, 'reload schema';
