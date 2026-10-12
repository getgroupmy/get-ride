-- ============================================================================
-- 0155: chat over Bluetooth when there's no signal (reliability Phase D3)
--
-- At the kerb the two phones are already in Bluetooth range (0153). A chat
-- message that can't reach the server goes phone to phone instead: the
-- driver's phone serves a small GATT service, the rider's connects to it.
-- Every frame is signed with a key only the two phones on the ride hold,
-- so nobody else in range can read the ids or put words in either mouth.
--
--   * reliability_ble() gains 'chat' (ble_chat in the reliability row; off);
--   * get_trip_ble_token() gains 'chat_key': HMAC(ride key, request : chat),
--     the same for both sides, never advertised, only handed out while the
--     chat switch is on.
--
-- The message still reaches the server under its own client_msg_id when a
-- connection is back (0146), so the thread ends up the same either way.
-- ============================================================================

create or replace function public.reliability_ble()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with v as (
    select coalesce((select e.values from public.settings_entries e
                      where e.id = '72656c69-6162-4c69-8000-000000000001'), '{}'::jsonb) as j
  )
  select jsonb_build_object(
    'enabled', coalesce(j->>'ble_enabled', '') in ('true', 't', '1', 'on'),
    'android', coalesce(j->>'ble_android', '') not in ('false', 'f', '0', 'off'),
    'ios', coalesce(j->>'ble_ios', '') not in ('false', 'f', '0', 'off'),
    'autostart_no_pin', coalesce(j->>'ble_autostart_no_pin', '') in ('true', 't', '1', 'on'),
    'rssi_threshold_dbm', greatest(-100, least(-30, coalesce(
        case when j->>'ble_rssi_threshold_dbm' ~ '^-?[0-9]+$' then (j->>'ble_rssi_threshold_dbm')::int end, -70))),
    'match_timeout_s', greatest(5, least(120, coalesce(
        case when j->>'ble_match_timeout_s' ~ '^[0-9]+$' then (j->>'ble_match_timeout_s')::int end, 20))),
    'chat', coalesce(j->>'ble_chat', '') in ('true', 't', '1', 'on')
  ) from v;
$$;
revoke execute on function public.reliability_ble() from public, anon;
grant execute on function public.reliability_ble() to authenticated;

create or replace function public.get_trip_ble_token(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  r public.ride_requests;
  v_side text;
  v_secret bytea;
  v_window bigint := public.ble_window();
  s jsonb := public.reliability_ble();
begin
  v_side := public.ble_ride_side(p_request);
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
    'peer_token', public.ble_token(v_secret, p_request,
                                   case v_side when 'driver' then 'rider' else 'driver' end, v_window),
    'expires_at', to_timestamp((v_window + 1) * 300),
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
