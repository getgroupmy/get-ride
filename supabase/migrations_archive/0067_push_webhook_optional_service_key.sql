-- ============================================================================
-- Push webhooks: make the Vault `service_role_key` secret optional
-- ----------------------------------------------------------------------------
-- The 0051 (new ride request) and 0065 (wallet transfer) triggers called the
-- `send-push` edge function with `Authorization: Bearer <service_role_key>`
-- read from Vault, and no-oped when EITHER Vault secret was missing. But
-- `send-push` is deployed with `--no-verify-jwt`, so the gateway never checks
-- that bearer — the function authenticates internally with its env-injected
-- service-role key. Requiring the secret only meant deployments that never ran
-- the Vault setup silently sent no partner notifications at all.
--
-- This migration routes all three webhook triggers through one shared helper,
-- `public.send_push_webhook(jsonb)`, which:
--   * still reads `project_url` from Vault (required — the DB cannot derive
--     its own project URL),
--   * attaches the Authorization header only when `service_role_key` exists,
--     and posts without it otherwise (valid because send-push is public),
--   * never raises — notification failures must not block the parent write.
--
-- Setup now needs just one secret (SQL editor, safe to re-run):
--   select vault.create_secret('https://YOURREF.supabase.co', 'project_url');
--
-- Safe to re-run.
-- ============================================================================

create extension if not exists pg_net with schema extensions;

create or replace function public.send_push_webhook(p_body jsonb)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url     text;
  v_key     text;
  v_headers jsonb;
begin
  -- Pull config from Vault; bail out gracefully if unreadable.
  begin
    select decrypted_secret into v_url
      from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_key
      from vault.decrypted_secrets where name = 'service_role_key' limit 1;
  exception when others then
    return;
  end;

  if v_url is null then
    return;
  end if;

  v_headers := jsonb_build_object('Content-Type', 'application/json');
  if v_key is not null then
    v_headers := v_headers || jsonb_build_object('Authorization', 'Bearer ' || v_key);
  end if;

  perform net.http_post(
    url     := v_url || '/functions/v1/send-push',
    headers := v_headers,
    body    := p_body
  );
exception when others then
  null;
end;
$$;

-- Trigger-internal helper; no reason for clients to call it directly.
revoke execute on function public.send_push_webhook(jsonb) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 0051: new open ride request -> notify the partner audience
-- ----------------------------------------------------------------------------
create or replace function public.notify_partners_on_ride_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_pickup text;
  v_body   text;
begin
  -- Only fire for brand-new open requests.
  if new.status is distinct from 'open' then
    return new;
  end if;

  v_pickup := coalesce(nullif(new.pickup_name, ''), nullif(new.pickup_address, ''), 'a nearby location');
  v_body   := 'Pickup at ' || v_pickup ||
              case when new.fare is not null
                   then ' • ' || coalesce(new.currency, '') || ' ' || new.fare::text
                   else '' end;

  perform public.send_push_webhook(jsonb_build_object(
    'title', 'New ride request',
    'body', v_body,
    'audience', 'partners',
    'data', jsonb_build_object(
      'type', 'ride_request',
      'ride_request_id', new.id
    )
  ));

  return new;
exception when others then
  -- Never let a notification failure block the ride request insert.
  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 0065: coin transfer request -> notify the recipient
-- ----------------------------------------------------------------------------
create or replace function public.notify_wallet_transfer_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
begin
  if new.status is distinct from 'pending' then
    return new;
  end if;

  perform public.send_push_webhook(jsonb_build_object(
    'title', 'GET.coin transfer request',
    'body', coalesce(nullif(new.from_name, ''), 'Someone')
            || ' wants to send you ' || new.coins::text || ' GC',
    'profileId', new.to_user_id,
    'data', jsonb_build_object(
      'type', 'wallet_transfer_request',
      'request_id', new.id
    )
  ));

  return new;
exception when others then
  -- Never let a notification failure block the request.
  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 0065: coin transfer resolved -> notify the sender
-- ----------------------------------------------------------------------------
create or replace function public.notify_wallet_transfer_response()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_body text;
begin
  if old.status is distinct from 'pending'
     or new.status not in ('accepted', 'declined', 'failed') then
    return new;
  end if;

  v_body := case new.status
    when 'accepted' then coalesce(nullif(new.to_name, ''), 'The recipient')
                         || ' approved your request — ' || new.coins::text || ' GC sent'
    when 'declined' then coalesce(nullif(new.to_name, ''), 'The recipient')
                         || ' declined your transfer of ' || new.coins::text || ' GC'
    else 'Your transfer of ' || new.coins::text || ' GC failed — not enough GET.coin'
  end;

  perform public.send_push_webhook(jsonb_build_object(
    'title', 'GET.coin transfer',
    'body', v_body,
    'profileId', new.from_user_id,
    'data', jsonb_build_object(
      'type', 'wallet_transfer_response',
      'request_id', new.id,
      'status', new.status
    )
  ));

  return new;
exception when others then
  return new;
end;
$$;

-- The triggers from 0051/0065 reference these functions by name, so replacing
-- the bodies above is enough — but re-create them idempotently in case this
-- migration runs on a database that never applied the originals.
do $$
begin
  drop trigger if exists trg_ride_request_push on public.ride_requests;
  create trigger trg_ride_request_push
    after insert on public.ride_requests
    for each row execute function public.notify_partners_on_ride_request();

  drop trigger if exists trg_wallet_transfer_request_push on public.wallet_transfer_requests;
  create trigger trg_wallet_transfer_request_push
    after insert on public.wallet_transfer_requests
    for each row execute function public.notify_wallet_transfer_request();

  drop trigger if exists trg_wallet_transfer_response_push on public.wallet_transfer_requests;
  create trigger trg_wallet_transfer_response_push
    after update on public.wallet_transfer_requests
    for each row execute function public.notify_wallet_transfer_response();
end$$;
