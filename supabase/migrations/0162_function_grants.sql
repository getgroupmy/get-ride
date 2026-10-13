-- ============================================================================
-- 0162: who may call which database function (security advisor clean-up)
--
-- Postgres grants EXECUTE on every new function to PUBLIC, so every
-- SECURITY DEFINER function here was callable by the `anon` role (signed
-- out) through /rest/v1/rpc. Each one already checks its caller (auth.uid(),
-- wallet_assert_caller, caller_is_admin) or is a trigger function that RPC
-- cannot invoke, so nothing was open -- but one forgotten check would have
-- been. This takes signed-out access away from the functions that are of no
-- use without a session, and leaves it where a signed-out caller needs it.
--
-- Stays callable signed out (anon keeps EXECUTE):
--   * helpers that row-level policies applying to `public`/`anon` call --
--     revoking them would break signed-out reads (branding, help articles):
--       caller_is_admin, is_admin, admin_can_edit, app_settings_secret_access,
--       caller_is_approved_partner
--   * the signed-out screens: profile_phone_lookup, verify_pin_for_login,
--     device_registration_status, device_prior_account_count (sign-in);
--     resolve_qr (QR links); ride_share_view (shared ride page);
--     get_coin_market_stats, get_coin_trade_quote (prices);
--     push_unregister_token (runs at sign-out, when the session may be gone)
--
-- Signed in only (EXECUTE from authenticated + service_role, not PUBLIC/anon):
--   admin_can_read, apply_referral, clear_login_pin, device_guard_set_config,
--   get_my_referrer, push_register_token, set_login_pin, and every wallet_*
--   RPC plus wallet_assert_caller.
--
-- Trigger functions (nobody calls these; EXECUTE is only checked when a
-- trigger is created, never when it fires): no EXECUTE for PUBLIC, anon or
-- authenticated.
--
-- Also pins search_path on three plain-arithmetic helpers the advisor flagged.
-- Functions are found by name across all overloads, and a name this database
-- doesn't have is skipped, so the migration replays on any older copy.
-- ============================================================================

do $$
declare
  fn record;
  signed_in text[] := array[
    'admin_can_read', 'apply_referral', 'clear_login_pin', 'device_guard_set_config',
    'get_my_referrer', 'push_register_token', 'set_login_pin',
    'wallet_assert_caller', 'wallet_award_ride_coins', 'wallet_cancel_transfer_request',
    'wallet_charge_ride_commission', 'wallet_pay', 'wallet_recharge_credit',
    'wallet_redeem_fare_coins', 'wallet_request_coin_transfer', 'wallet_respond_coin_transfer',
    'wallet_trade_coins', 'wallet_transfer_coins'];
  triggers text[] := array[
    'ev_orders_freeze_owner', 'handle_new_auth_user', 'notify_partners_on_ride_request',
    'notify_wallet_transfer_request', 'notify_wallet_transfer_response',
    'ride_requests_guard_coverage', 'ride_requests_protect_rider',
    'support_calls_clear_signals', 'wallet_apply_transaction'];
begin
  for fn in
    select p.oid::regprocedure as sig from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = any(signed_in)
  loop
    execute format('revoke execute on function %s from public, anon', fn.sig);
    execute format('grant execute on function %s to authenticated, service_role', fn.sig);
  end loop;

  for fn in
    select p.oid::regprocedure as sig from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = any(triggers)
       and p.prorettype = 'trigger'::regtype
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', fn.sig);
  end loop;

  for fn in
    select p.oid::regprocedure as sig from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('ble_window', 'ble_windows_ahead', 'geo_distance_m')
  loop
    execute format('alter function %s set search_path = public', fn.sig);
  end loop;
end
$$;
